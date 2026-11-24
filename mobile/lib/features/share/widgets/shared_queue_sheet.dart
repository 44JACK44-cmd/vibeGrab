import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../data/models/download_task.dart';
import '../../../services/share_intent_handler.dart';
import '../../downloads/controllers/downloads_controller.dart';
import '../controllers/shared_download_controller.dart';

/// Contextual panel shown when several links arrive in one share event.
///
/// It lets the user pick which links are worth analysing. Each selected link
/// is analysed with the existing controller (same cache and format picker as
/// the single-link sheet) and enqueued with the user's default quality. Links
/// that cannot be analysed are reported, never silently skipped.
class SharedQueueSheet extends StatefulWidget {
  final List<String> urls;
  final bool overlay;

  const SharedQueueSheet({
    super.key,
    required this.urls,
    this.overlay = false,
  });

  @override
  State<SharedQueueSheet> createState() => _SharedQueueSheetState();
}

class _SharedQueueSheetState extends State<SharedQueueSheet> {
  late final Set<String> _selected;
  bool _working = false;
  int _done = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected = <String>{...widget.urls};
  }

  Future<void> _downloadSelected() async {
    if (_working || _selected.isEmpty || !mounted) return;
    setState(() {
      _working = true;
      _done = 0;
      _error = null;
    });

    final downloads = context.read<DownloadsController>();
    final loc = AppLocalizations.of(context);
    final selected = _selected.toList();
    var failures = 0;

    for (final url in selected) {
      if (!mounted) break;
      final controller = SharedDownloadController();
      await controller.analyzeUrl(url);
      if (!mounted) break;
      setState(() => _done++);

      if (controller.status != SharedSheetStatus.ready ||
          controller.selectedFormat == null) {
        failures++;
        continue;
      }
      final format = controller.selectedFormat!;
      final media = controller.media;
      final task = DownloadTask(
        id: 'dl_${DateTime.now().microsecondsSinceEpoch}',
        url: url,
        title: media?.title ?? loc.untitled,
        formatId: format.id,
        thumbnail: media?.thumbnail,
        source: media?.source,
        hasVideo: format.hasVideo,
        hasAudio: format.hasAudio,
        directUrl: format.directUrl,
        fileExt: format.extension,
        totalBytes: format.sizeBytes,
        mediaType: format.type == 'audio'
            ? DownloadMediaType.audio
            : DownloadMediaType.video,
        createdAt: DateTime.now().toIso8601String(),
      );
      downloads.addTask(task);
    }

    if (!mounted) return;
    setState(() {
      _working = false;
      if (failures > 0) {
        _error = '${loc.shareQueueSomeFailed}: $failures';
      }
    });
    if (failures == 0) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loc = AppLocalizations.of(context);
    return PopScope(
      canPop: !_working,
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 4),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Row(
                    children: [
                      Icon(Icons.queue_music_rounded, size: 20, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${loc.shareQueueTitle} (${widget.urls.length})',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: widget.urls.length,
                    itemBuilder: (context, index) {
                      final url = widget.urls[index];
                      final platform =
                          ShareIntentHandler.detectPlatform(url) ?? 'web';
                      final selected = _selected.contains(url);
                      return Material(
                        color: Colors.transparent,
                        child: CheckboxListTile(
                        value: selected,
                        onChanged: _working
                            ? null
                            : (v) => setState(() {
                                  if (v == true) {
                                    _selected.add(url);
                                  } else {
                                    _selected.remove(url);
                                  }
                                }),
                        title: Text(
                          url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(platform,
                            style: TextStyle(
                                fontSize: 11, color: cs.onSurfaceVariant)),
                        ),
                      );
                    },
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(_error!,
                        style: TextStyle(color: cs.error, fontSize: 12)),
                  ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Column(
                      children: [
                        if (_working)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              '${loc.shareQueueAnalyzing} $_done/${_selected.length}',
                              style: TextStyle(
                                  fontSize: 12, color: cs.onSurfaceVariant),
                            ),
                          ),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextButton(
                                onPressed: _working
                                    ? null
                                    : () => setState(() {
                                          _selected = _selected.isEmpty
                                              ? {...widget.urls}
                                              : <String>{};
                                        }),
                                child: FittedBox(
                                  child: Text(_selected.isEmpty
                                      ? loc.shareQueueSelectAll
                                      : loc.shareQueueClear),
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: TextButton(
                                onPressed: _working
                                    ? null
                                    : () => Navigator.of(context).pop(),
                                child: FittedBox(child: Text(loc.cancel)),
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  minimumSize: Size.zero,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8),
                                ),
                                onPressed: _working || _selected.isEmpty
                                    ? null
                                    : _downloadSelected,
                                child: FittedBox(
                                  child: Text(
                                    loc.shareQueueDownloadAll,
                                    maxLines: 1,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
