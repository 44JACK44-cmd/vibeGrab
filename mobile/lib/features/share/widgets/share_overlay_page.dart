import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../services/share_intent_handler.dart';
import '../../downloads/controllers/downloads_controller.dart';
import '../controllers/shared_download_controller.dart';
import 'shared_download_sheet.dart';

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
    final url = handler.pendingUrl;
    if (url == null || url.isEmpty) {
      _close();
      return;
    }
    handler.consumePendingUrl();

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

    await SharedDownloadSheet.show(context, controller, overlay: true);

    if (mounted) {
      controller.reset();
    }
    _close();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    const MethodChannel('com.example.vibegrab/app')
        .invokeMethod('closeActivity')
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
