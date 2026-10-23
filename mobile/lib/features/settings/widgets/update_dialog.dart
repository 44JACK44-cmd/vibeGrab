import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        builder: (_) => UpdateAvailableDialog(info: info),
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

/// Dialog shown when a newer version is available.
///
/// It is public so a widget test can open it with the real release notes of
/// a long version: the notes of a big release are the only content the
/// installed app has (the catalogue inside the binary knows older versions).
class UpdateAvailableDialog extends StatefulWidget {
  final UpdateInfo info;

  const UpdateAvailableDialog({super.key, required this.info});

  @override
  State<UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<UpdateAvailableDialog>
    with WidgetsBindingObserver {
  /// Download progress (null = not downloading).
  double? _progress;

  /// Error shown in the fixed panel under the buttons.
  String? _error;

  /// The APK is downloaded and the installer is being opened.
  bool _installing = false;

  /// Path of the APK already downloaded. Kept across the "allow installing
  /// apps" detour so coming back does not download ~26 MB again.
  String? _apkPath;

  /// The last failure was the install permission: retry on resume.
  bool _permissionError = false;

  bool get _busy => _progress != null || _installing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!_permissionError || _apkPath == null || _busy) return;
    _retryInstallIfAllowed();
  }

  /// The user went to the system screen and came back. Install only when the
  /// permission is actually granted: otherwise opening the settings screen
  /// again on every resume would trap the user in a loop.
  Future<void> _retryInstallIfAllowed() async {
    final allowed = await UpdateService.canInstallPackages();
    if (!mounted || !allowed) return;
    await _install();
  }

  Future<void> _start() async {
    if (_apkPath != null) {
      await _install();
      return;
    }
    await _download();
  }

  Future<void> _download() async {
    setState(() {
      _progress = 0.0;
      _error = null;
      _installing = false;
      _permissionError = false;
    });
    try {
      final path = await UpdateService.download(widget.info, (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      _apkPath = path;
      await _install();
    } catch (e) {
      debugPrint('[Update] download failed: $e');
      if (!mounted) return;
      final loc = AppLocalizations.of(context);
      setState(() {
        _progress = null;
        _installing = false;
        _error = loc.updateFailed;
        _permissionError = false;
      });
    }
  }

  Future<void> _install() async {
    final path = _apkPath;
    if (path == null) {
      await _download();
      return;
    }
    setState(() {
      _error = null;
      _progress = null;
      _installing = true;
      _permissionError = false;
    });
    try {
      await UpdateService.install(path);
      if (mounted) Navigator.of(context).pop();
    } on PlatformException catch (e) {
      debugPrint('[Update] install failed: ${e.code} ${e.message}');
      if (!mounted) return;
      final loc = AppLocalizations.of(context);
      final needsPermission = e.code == 'INSTALL_PERMISSION_REQUIRED';
      setState(() {
        _installing = false;
        _permissionError = needsPermission;
        // A raw ActivityNotFoundException is not something a user can act
        // on; the localized line tells them what to do.
        _error = needsPermission ? loc.updatePermissionRequired : loc.updateFailed;
        if (!needsPermission) _apkPath = null;
      });
    } catch (e) {
      debugPrint('[Update] install failed: $e');
      if (!mounted) return;
      final loc = AppLocalizations.of(context);
      setState(() {
        _installing = false;
        _permissionError = false;
        _apkPath = null;
        _error = loc.updateFailed;
      });
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

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The notes of a big release are longer than the screen. The
            // scroll view receives the height limit from the dialog itself:
            // an inner ConstrainedBox capped the column at 460 px while the
            // column kept its real height, so the text overflowed the
            // dialog, covered the buttons and the screen never scrolled.
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(loc.updateTitle,
                        style: text.titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text(loc.updateBody, style: text.bodyMedium),
                    const SizedBox(height: 4),
                    Text('v${info.versionName}', style: text.titleMedium),
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
                      Text(notes, style: text.bodySmall),
                    ],
                  ],
                ),
              ),
            ),
            // The download state lives OUTSIDE the scrollable area: inside it
            // the progress bar was below the notes, so the user pressed
            // "Actualizar ahora" and saw nothing happen.
            if (_progress != null || _error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: _UpdateProgressPanel(
                  progress: _progress,
                  error: _error,
                  installing: _installing,
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 4,
                overflowAlignment: OverflowBarAlignment.end,
                overflowDirection: VerticalDirection.down,
                children: [
                  TextButton(
                    onPressed:
                        _busy ? null : () => Navigator.of(context).pop(),
                    child: Text(loc.updateLater),
                  ),
                  FilledButton(
                    onPressed: _busy ? null : _start,
                    child: Text(_busy ? loc.updateWorking : loc.updateNow),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fixed panel with the state of the update: downloading, installing or
/// failed. It is never inside the scroll view, so it is always visible.
class _UpdateProgressPanel extends StatelessWidget {
  final double? progress;
  final String? error;
  final bool installing;

  const _UpdateProgressPanel({
    required this.progress,
    required this.error,
    required this.installing,
  });

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    if (error != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: cs.error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error!,
              style: text.bodySmall?.copyWith(color: cs.error),
            ),
          ),
        ],
      );
    }

    final value = progress ?? 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: progress == null ? null : value,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                installing ? loc.updateInstalling : loc.updateDownloading,
                style: text.bodySmall,
              ),
            ),
            if (progress != null)
              Text(
                '${(value * 100).toStringAsFixed(0)}%',
                style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
              ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: progress == null ? null : value),
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
