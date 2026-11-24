import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../services/share_intent_handler.dart';
import '../../downloads/controllers/downloads_controller.dart';
import '../controllers/shared_download_controller.dart';
import 'shared_download_sheet.dart';
import 'shared_queue_sheet.dart';

/// Translucent page used while VibeGrab was opened by a share intent.
///
/// It never navigates into the main shell: the source app stays visible
/// behind it and closing the panel only finishes this activity.
class ShareOverlayPage extends StatefulWidget {
  const ShareOverlayPage({super.key});

  @override
  State<ShareOverlayPage> createState() => _ShareOverlayPageState();
}

class _ShareOverlayPageState extends State<ShareOverlayPage> {
  bool _started = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;

    final handler = ShareIntentHandler();
    while (mounted) {
      final queued = handler.queuedUrls;
      if (queued.isEmpty) {
        handler.exitOverlay();
        _close();
        return;
      }

      if (queued.length > 1) {
        if (!mounted) return;
        await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => SharedQueueSheet(
            urls: List<String>.from(queued),
            overlay: true,
          ),
        );
        if (!mounted) return;
        for (final url in queued) {
          handler.removeUrl(url);
        }
        // A new share may have arrived while the panel was open.
        continue;
      }

      final url = handler.consumePendingUrl();
      if (url == null) break;
      if (!mounted) {
        _close();
        return;
      }

      final controller = context.read<SharedDownloadController>();
      await context.read<DownloadsController>().init();
      controller.analyzeUrl(url);

      if (!mounted) {
        _close();
        return;
      }

      final dynamic sheetResult =
          await SharedDownloadSheet.show(context, controller, overlay: true);
      controller.reset();

      if (sheetResult == 'background') {
        handler.exitOverlay();
        const MethodChannel('com.example.vibegrab/app')
            .invokeMethod('backgroundOverlay')
            .catchError((_) {});
        return;
      }
    }
    _close();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    // Every close path must drop overlay mode and the queue. Leaving either
    // set made the next normal launch open the translucent page and replay
    // an old link.
    ShareIntentHandler().exitOverlay();
    const MethodChannel('com.example.vibegrab/app')
        .invokeMethod('closeShareOverlay')
        .catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.transparent,
      body: SizedBox.expand(),
    );
  }
}
