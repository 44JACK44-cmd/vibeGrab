import 'package:flutter/material.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../services/update_service.dart';
import '../../whats_new/data/release_notes.dart';
import '../../whats_new/data/whats_new_catalog.dart';
import '../../whats_new/widgets/whats_new_dialog.dart';

class UpdateDialog {
  static bool _showing = false;

  static Future<void> checkAndShow(
    BuildContext context, {
    bool manual = false,
  }) async {
    if (_showing) return;
    _showing = true;
    BuildContext? spinnerContext;
    try {
      final loc = AppLocalizations.of(context);
      if (manual) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            spinnerContext = ctx;
            return AlertDialog(
              content: Row(
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(width: 16),
                  Text(loc.updateChecking),
                ],
              ),
            );
          },
        );
      }

      final info = await UpdateService.checkForUpdate();

      if (manual && spinnerContext != null) {
        final spinner = spinnerContext!;
        if (spinner.mounted) {
          Navigator.of(spinner).pop();
        }
        spinnerContext = null;
      }

      if (info == null) {
        if (manual && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(loc.updateLatest)),
          );
        }
        return;
      }

      if (!context.mounted || _showing == false) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _UpdateAvailableDialog(info: info),
      );
    } catch (e) {
      debugPrint('[Update] check failed: $e');
      if (spinnerContext != null) {
        final spinner = spinnerContext!;
        if (spinner.mounted) {
          Navigator.of(spinner).pop();
        }
        spinnerContext = null;
      }
      if (manual && context.mounted) {
        final loc = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.updateCheckFailed)),
        );
      }
    } finally {
      _showing = false;
    }
  }
}

class _UpdateAvailableDialog extends StatefulWidget {
  final UpdateInfo info;

  const _UpdateAvailableDialog({required this.info});

  @override
  State<_UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<_UpdateAvailableDialog> {
  double? _progress;
  bool _failed = false;

  Future<void> _download() async {
    setState(() {
      _progress = 0.0;
      _failed = false;
    });
    try {
      final path = await UpdateService.download(widget.info, (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      await UpdateService.install(path);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      debugPrint('[Update] download failed: $e');
      if (mounted) {
        setState(() {
          _progress = null;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final info = widget.info;
    final notes = info.notes.trim();
    final lang = Localizations.localeOf(context).languageCode;
    final text = Theme.of(context).textTheme;
    final entries =
        WhatsNewCatalog.forVersion(info.versionName, info.buildNumber);
    final highlights = WhatsNewCatalog.highlights(entries, max: 4);
    // The catalogue ships inside the binary, so an update the app has never
    // heard of arrives with no entries at all. The release notes are the
    // only source then, and they are presented with the same care instead of
    // as a wall of text.
    final sections =
        highlights.isEmpty ? ReleaseNotes.parse(notes, lang) : null;

    return AlertDialog(
      title: Text(loc.updateTitle),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(loc.updateBody),
              const SizedBox(height: 6),
              Text(
                'v${info.versionName}',
                style: text.titleMedium,
              ),
              if (highlights.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final entry in highlights)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ExcludeSemantics(
                          child: Text(entry.emoji,
                              style: const TextStyle(fontSize: 15)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            entry.title.resolve(lang),
                            style: text.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => WhatsNewDialog.show(
                      context,
                      groups: WhatsNewCatalog.groupByVersion(entries),
                      isUpdate: false,
                    ),
                    child: Text(loc.whatsNewOpenFull),
                  ),
                ),
              ] else if (sections != null) ...[
                const SizedBox(height: 14),
                for (final section in sections) ...[
                  if (section.title.isNotEmpty) ...[
                    Text(
                      section.title,
                      style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  for (final item in section.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ReleaseNoteRow(item: item),
                    ),
                  const SizedBox(height: 4),
                ],
              ] else if (notes.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      notes,
                      style: text.bodySmall,
                    ),
                  ),
                ),
              ],
              if (_progress != null) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 6),
                Text('${(_progress! * 100).toStringAsFixed(0)}%'),
              ],
              if (_failed) ...[
                const SizedBox(height: 12),
                Text(
                  loc.updateFailed,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(loc.updateLater),
        ),
        FilledButton(
          onPressed: _progress != null ? null : _download,
          child: Text(loc.updateNow),
        ),
      ],
    );
  }
}

/// One line of the release notes, styled like the catalogue cards.
class _ReleaseNoteRow extends StatelessWidget {
  final ReleaseNoteItem item;

  const _ReleaseNoteRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final hasTitle = item.title.isNotEmpty;
    final hasBody = item.body.isNotEmpty;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: ExcludeSemantics(
            child: Text(
              item.emoji.isEmpty ? '•' : item.emoji,
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasTitle)
                Text(
                  item.title,
                  style: text.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              if (hasBody) ...[
                if (hasTitle) const SizedBox(height: 2),
                Text(
                  item.body,
                  style: text.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
