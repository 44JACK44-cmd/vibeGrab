import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_animations.dart';
import '../../share/controllers/shared_download_controller.dart';
import '../../share/widgets/shared_download_sheet.dart';
import '../url_detector/browser_url_detector.dart';

/// Built-in browser tab: browse YouTube / TikTok / Instagram... and download
/// any detected media page through the shared format sheet.
class BrowserView extends StatefulWidget {
  const BrowserView({super.key});

  @override
  State<BrowserView> createState() => _BrowserViewState();
}

class _BrowserViewState extends State<BrowserView> {
  late final WebViewController _web;
  final TextEditingController _urlBar = TextEditingController();
  final FocusNode _urlFocus = FocusNode();

  bool _loading = true;
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String? _currentUrl;

  static const _homeUrl = 'https://www.youtube.com';

  // Desktop UA: mobile YouTube pushes the native app overlay and hides the
  // normal watch page inside WebViews; the desktop site behaves like PC.
  static const _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopUa)
      ..setBackgroundColor(Theme.of(context).colorScheme.surface)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (value) => setState(() => _progress = value / 100),
        onPageStarted: (url) {
          setState(() {
            _loading = true;
            _currentUrl = url;
            _syncUrlBar(url);
          });
        },
        onPageFinished: _onPageFinished,
      ));
    _web.loadRequest(Uri.parse(_homeUrl));
  }

  Future<void> _onPageFinished(String url) async {
    final canBack = await _web.canGoBack();
    final canForward = await _web.canGoForward();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _currentUrl = url;
      _canGoBack = canBack;
      _canGoForward = canForward;
    });
  }

  void _syncUrlBar(String url) {
    if (_urlFocus.hasFocus) return;
    _urlBar.text = url;
  }

  void _submitUrl(String value) {
    _urlFocus.unfocus();
    final text = value.trim();
    if (text.isEmpty) return;
    final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    if (uri == null || uri.host.isEmpty) return;
    _web.loadRequest(uri);
  }

  /// Non-null when the current page is a downloadable media page.
  String? get _downloadable =>
      BrowserUrlDetector.downloadableUrl(_currentUrl ?? '');

  void _openDownloadSheet() {
    final url = _downloadable;
    if (url == null || !mounted) return;
    final controller = context.read<SharedDownloadController>();
    controller.analyzeUrl(url);
    SharedDownloadSheet.show(context, controller);
  }

  @override
  void dispose() {
    _urlBar.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final downloadable = _downloadable;

    return Stack(
      children: [
        Column(
          children: [
            _buildToolbar(cs, loc),
            if (_loading)
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 2,
              ),
            Expanded(child: WebViewWidget(controller: _web)),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: AnimatedSlide(
            duration: AppDurations.normal,
            curve: AppCurves.easeOut,
            offset: downloadable != null ? Offset.zero : const Offset(0, 1.5),
            child: AnimatedOpacity(
              opacity: downloadable != null ? 1 : 0,
              duration: AppDurations.normal,
              child: FloatingActionButton.extended(
                onPressed: downloadable != null ? _openDownloadSheet : null,
                icon: const Icon(Icons.download_rounded),
                label: Text(loc.shareDownload),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(ColorScheme cs, AppLocalizations loc) {
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
              onPressed: _canGoBack ? () => _web.goBack() : null,
              tooltip: loc.back,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_rounded, size: 20),
              onPressed: _canGoForward ? () => _web.goForward() : null,
            ),
            Expanded(
              child: TextField(
                controller: _urlBar,
                focusNode: _urlFocus,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                onSubmitted: _submitUrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: loc.browserUrlHint,
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                  prefixIcon: Icon(Icons.search_rounded,
                      size: 18, color: cs.onSurfaceVariant),
                  suffixIcon: _urlBar.text.isEmpty
                      ? null
                      : IconButton(
                          icon: Icon(Icons.clear_rounded,
                              size: 16, color: cs.onSurfaceVariant),
                          onPressed: () {
                            _urlBar.clear();
                            setState(() {});
                          },
                        ),
                  isDense: true,
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20),
              onPressed: () => _web.reload(),
              tooltip: loc.retry,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              padding: EdgeInsets.zero,
              onSelected: (action) async {
                switch (action) {
                  case 'home':
                    _web.loadRequest(Uri.parse(_homeUrl));
                    break;
                  case 'external':
                    final url = _currentUrl;
                    if (url != null) {
                      await launchUrl(Uri.parse(url),
                          mode: LaunchMode.externalApplication);
                    }
                    break;
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'home',
                  child: Row(children: [
                    const Icon(Icons.home_outlined, size: 18),
                    const SizedBox(width: 10),
                    Text(loc.navHome),
                  ]),
                ),
                PopupMenuItem(
                  value: 'external',
                  child: Row(children: [
                    const Icon(Icons.open_in_new_rounded, size: 18),
                    const SizedBox(width: 10),
                    Text(loc.browserOpenExternal),
                  ]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
