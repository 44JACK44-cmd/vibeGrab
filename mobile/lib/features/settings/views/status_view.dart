import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../services/status_service.dart';

class StatusView extends StatefulWidget {
  const StatusView({super.key});

  @override
  State<StatusView> createState() => _StatusViewState();
}

class _StatusViewState extends State<StatusView> with WidgetsBindingObserver {
  StatusAccess? _access;
  List<StatusFile> _statuses = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _access != null && !_busy) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final access = await StatusService.instance.checkAccess();
    List<StatusFile> statuses = const [];
    if (access == StatusAccess.granted) {
      statuses = await StatusService.instance.list();
    }
    if (!mounted) return;
    setState(() {
      _access = access;
      _statuses = statuses;
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _requestMedia() async {
    if (_busy) return;
    setState(() => _busy = true);
    await StatusService.instance.requestMediaPermission();
    if (!mounted) return;
    setState(() => _busy = false);
    _refresh();
  }

  Future<void> _requestManage() async {
    if (_busy) return;
    setState(() => _busy = true);
    await StatusService.instance.requestManagePermission();
    if (!mounted) return;
    setState(() => _busy = false);
    _refresh();
  }

  Future<void> _save(StatusFile status, AppLocalizations loc) async {
    final ok = await StatusService.instance.saveToGallery(status);
    _snack(ok ? loc.statusSaved : loc.statusSaveError);
  }

  Future<void> _saveAll(AppLocalizations loc) async {
    if (_busy) return;
    setState(() => _busy = true);
    var ok = 0;
    for (final s in _statuses) {
      if (await StatusService.instance.saveToGallery(s)) ok++;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == _statuses.length) {
      _snack(loc.statusSaved);
    } else if (ok > 0) {
      _snack('$ok/${_statuses.length} ${loc.statusSaved}');
    } else {
      _snack(loc.statusSaveError);
    }
  }

  void _openPreview(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StatusPreviewPage(
          statuses: _statuses,
          initialIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.statusSaver),
        actions: [
          if (_access == StatusAccess.granted && _statuses.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.download),
              tooltip: loc.statusSaveAll,
              onPressed: _busy ? null : () => _saveAll(loc),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: _buildBody(loc, cs),
    );
  }

  Widget _buildBody(AppLocalizations loc, ColorScheme cs) {
    if (_access == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_access == StatusAccess.granted) {
      return _statuses.isEmpty ? _buildEmpty(loc, cs) : _buildGrid(loc, cs);
    }
    if (_access == StatusAccess.needMedia) {
      return _buildNeedMedia(loc, cs);
    }
    if (_access == StatusAccess.needManage) {
      return _buildNeedManage(loc, cs);
    }
    return _buildUnsupported(loc, cs);
  }

  Widget _buildEmpty(AppLocalizations loc, ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_outlined,
              size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              loc.statusEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(loc.refresh),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(AppLocalizations loc, ColorScheme cs) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.72,
      ),
      itemCount: _statuses.length,
      itemBuilder: (context, index) {
        final status = _statuses[index];
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openPreview(index),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (!status.isVideo)
                  Image.file(
                    status.file,
                    fit: BoxFit.cover,
                    cacheWidth: 300,
                    errorBuilder: (_, __, ___) => _placeholder(cs, false),
                  )
                else
                  _placeholder(cs, true),
                if (status.isVideo)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.play_arrow,
                          color: Colors.white, size: 16),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder(ColorScheme cs, bool video) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.primary.withValues(alpha: 0.25),
            cs.primary.withValues(alpha: 0.08),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          video ? Icons.videocam_outlined : Icons.image_outlined,
          color: cs.primary,
          size: 32,
        ),
      ),
    );
  }

  Widget _gateBody(
      AppLocalizations loc, ColorScheme cs, IconData icon, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: cs.primary.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurface, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNeedMedia(AppLocalizations loc, ColorScheme cs) {
    return Column(
      children: [
        Expanded(child: _gateBody(loc, cs, Icons.lock_outline, loc.statusNoPermission)),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _requestMedia,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.perm_identity),
              label: Text(loc.statusGrant),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNeedManage(AppLocalizations loc, ColorScheme cs) {
    return Column(
      children: [
        Expanded(
          child: _gateBody(
              loc, cs, Icons.folder_off_outlined, loc.statusAllFilesHint),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _requestManage,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.admin_panel_settings_outlined),
              label: Text(loc.statusAllFiles),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUnsupported(AppLocalizations loc, ColorScheme cs) {
    return _gateBody(loc, cs, Icons.search_off, loc.statusUnavailable);
  }
}

class StatusPreviewPage extends StatefulWidget {
  final List<StatusFile> statuses;
  final int initialIndex;

  const StatusPreviewPage({
    super.key,
    required this.statuses,
    required this.initialIndex,
  });

  @override
  State<StatusPreviewPage> createState() => _StatusPreviewPageState();
}

class _StatusPreviewPageState extends State<StatusPreviewPage> {
  late final PageController _pageController;
  late int _index;
  VideoPlayerController? _video;
  bool _videoReady = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageController = PageController(initialPage: _index);
    _initVideo();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _video?.dispose();
    super.dispose();
  }

  StatusFile get _current => widget.statuses[_index];

  Future<void> _initVideo() async {
    final status = _current;
    if (!status.isVideo) return;
    final controller = VideoPlayerController.file(File(status.path));
    _video = controller;
    try {
      await controller.initialize();
      controller.setLooping(true);
      await controller.play();
    } catch (_) {}
    if (mounted) {
      setState(() => _videoReady = true);
    }
  }

  void _disposeVideo() {
    _video?.dispose();
    _video = null;
    _videoReady = false;
  }

  void _onPageChanged(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    _disposeVideo();
    _initVideo();
  }

  Future<void> _save(AppLocalizations loc) async {
    if (_saving) return;
    setState(() => _saving = true);
    final ok = await StatusService.instance.saveToGallery(_current);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(ok ? loc.statusSaved : loc.statusSaveError)));
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(_current.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14)),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.statuses.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          final status = widget.statuses[index];
          if (status.isVideo) {
            if (index == _index && _videoReady && _video != null) {
              return Center(
                child: AspectRatio(
                  aspectRatio: _video!.value.aspectRatio == 0
                      ? 9 / 16
                      : _video!.value.aspectRatio,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      VideoPlayer(_video!),
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: _video!,
                        builder: (context, value, _) {
                          if (!value.isPlaying) {
                            return GestureDetector(
                              onTap: () => _video!.play(),
                              child: Container(
                                padding: const EdgeInsets.all(18),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.4),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.play_arrow,
                                    color: Colors.white, size: 42),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ],
                  ),
                ),
              );
            }
            return const Center(
              child: Icon(Icons.videocam_outlined,
                  color: Colors.white54, size: 56),
            );
          }
          return InteractiveViewer(
            child: Center(
              child: Image.file(
                File(status.path),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Center(
                  child: Icon(Icons.broken_image_outlined,
                      color: Colors.white54, size: 56),
                ),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: Colors.black,
          child: Row(
            children: [
              if (_current.isVideo && _videoReady && _video != null)
                IconButton(
                  icon: Icon(
                    _video!.value.isPlaying
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                    color: Colors.white,
                    size: 30,
                  ),
                  onPressed: () {
                    setState(() {
                      _video!.value.isPlaying
                          ? _video!.pause()
                          : _video!.play();
                    });
                  },
                ),
              const Spacer(),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: Colors.white,
                ),
                onPressed: _saving ? null : () => _save(loc),
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.download, size: 18),
                label: Text(loc.saveOne),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
