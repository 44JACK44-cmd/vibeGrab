import 'package:flutter/material.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../services/update_service.dart';

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
        Navigator.of(spinnerContext!).pop();
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
        Navigator.of(spinnerContext!).pop();
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

    return AlertDialog(
      title: Text(loc.updateTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loc.updateBody),
          const SizedBox(height: 6),
          Text(
            'v${info.versionName}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 140),
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: Text(
                  notes,
                  style: Theme.of(context).textTheme.bodySmall,
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
