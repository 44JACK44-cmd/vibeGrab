import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_animations.dart';
import '../../../services/browser_blocker_service.dart';
import '../../downloads/controllers/downloads_controller.dart';
import '../../share/controllers/shared_download_controller.dart';
import '../../share/widgets/shared_download_sheet.dart';
import '../url_detector/browser_url_detector.dart';

/// Built-in general-purpose browser. Opens on a start page of brand shortcuts
/// (no site is auto-loaded), accepts any URL or free-text search, and downloads
/// any detected media page through the shared format sheet.
class BrowserView extends StatefulWidget {
  /// False while another bottom tab is visible. Android's back button must
  /// then leave the app instead of silently navigating the hidden WebView.
  final bool isActive;

  const BrowserView({super.key, this.isActive = true});

  @override
  State<BrowserView> createState() => _BrowserViewState();
}

/// A brand shortcut card on the browser start page.
class _BrowserSite {
  final String label;
  final String url;
  final List<Color> colors;
  final IconData icon;
  final String? glyph;

  const _BrowserSite(
    this.label,
    this.url,
    this.colors, {
    this.icon = Icons.language_rounded,
    this.glyph,
  });
}

class _BrowserViewState extends State<BrowserView> {
  late final WebViewController _web;
  final TextEditingController _urlBar = TextEditingController();
  final TextEditingController _homeSearch = TextEditingController();
  final FocusNode _urlFocus = FocusNode();
  final FocusNode _homeFocus = FocusNode();

  bool _showHome = true;
  bool _loading = false;
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _desktopMode = true;
  String? _currentUrl;
  String? _loadError;
  bool _blockerInjectedEarly = false;

  // Desktop UA: mobile YouTube pushes the native app overlay and hides the
  // normal watch page inside WebViews; the desktop site behaves like PC.
  static const _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// Extensions that are a file, not a page. Clicking one downloads it with
  /// the normal download manager instead of replacing the page with bytes.
  static const _directFileExtensions = {
    'pdf', 'zip', 'rar', '7z', 'tar', 'gz', 'apk', 'exe', 'msi', 'dmg',
    'iso', 'torrent', 'epub', 'mobi', 'doc', 'docx', 'xls', 'xlsx', 'ppt',
    'pptx', 'txt', 'csv', 'json', 'xml',
    'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'opus',
    'mp4', 'm4v', 'webm', 'mkv', 'mov', 'avi',
    'jpg', 'jpeg', 'png', 'webp', 'gif',
  };

  // Host-like token ending in a real TLD, so "1.5" or "version 2" fall through
  // to a web search instead of being forced into a URL.
  static final _hostLike = RegExp(
    r'^(?:[\w-]+\.)+[a-zA-Z]{2,}(?::\d+)?(?:[/?#]\S*)?$',
  );

  // Brand colors kept realistic so the tiles read as the real services.
  static const _sites = <_BrowserSite>[
    _BrowserSite(
      'YouTube',
      'https://www.youtube.com',
      [Color(0xFFFF0033), Color(0xFFB30000)],
      icon: Icons.play_circle_fill_rounded,
    ),
    _BrowserSite(
      'TikTok',
      'https://www.tiktok.com',
      [Color(0xFF141414), Color(0xFF2E2E2E)],
      icon: Icons.music_note_rounded,
    ),
    _BrowserSite(
      'Instagram',
      'https://www.instagram.com',
      [Color(0xFF833AB4), Color(0xFFE1306C)],
      icon: Icons.camera_alt_rounded,
    ),
    _BrowserSite(
      'Facebook',
      'https://m.facebook.com',
      [Color(0xFF1877F2), Color(0xFF0B5ED7)],
      icon: Icons.facebook,
    ),
    _BrowserSite(
      'X',
      'https://x.com',
      [Color(0xFF000000), Color(0xFF16181C)],
      glyph: 'X',
    ),
    _BrowserSite(
      'SoundCloud',
      'https://soundcloud.com',
      [Color(0xFFFF5500), Color(0xFFFF8A00)],
      icon: Icons.graphic_eq_rounded,
    ),
    _BrowserSite(
      'Vimeo',
      'https://vimeo.com',
      [Color(0xFF1AB7EA), Color(0xFF0F80B5)],
      icon: Icons.videocam_rounded,
    ),
    _BrowserSite(
      'Dailymotion',
      'https://www.dailymotion.com',
      [Color(0xFF0066DC), Color(0xFF0044A0)],
      icon: Icons.movie_rounded,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _urlBar.addListener(_onUrlBarChanged);
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopUa)
      ..setBackgroundColor(Theme.of(context).colorScheme.surface)
      ..addJavaScriptChannel(
        BrowserBlockerService.channelName,
        onMessageReceived: (message) {
          // {id, count}: the script reports its cumulative count, possibly
          // many times per page. A plain number is still accepted.
          final raw = message.message.trim();
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map) {
              final count = decoded['count'];
              final id = decoded['id']?.toString();
              if (count is num) {
                BrowserBlockerService.instance
                    .reportBlocked(count.toInt(), session: id);
              }
              return;
            }
          } catch (_) {
            // Not JSON: fall back to the old plain-number contract.
          }
          final count = int.tryParse(raw);
          if (count == null) return;
          BrowserBlockerService.instance.reportBlocked(count);
        },
      )
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (value) {
          if (mounted) setState(() => _progress = value / 100);
          // Head start: as soon as the new document exists, install the
          // filter. Waiting for onPageFinished meant the whole first wave of
          // sub-resources had already been requested. This is best effort
          // (webview_flutter has no document-start hook), so onPageFinished
          // re-injects for the rest of the page's life.
          if (value > 0 && value < 100 && !_blockerInjectedEarly) {
            _blockerInjectedEarly = true;
            _injectBlocker();
          }
        },
        onPageStarted: (url) {
          _blockerInjectedEarly = false;
          if (!mounted) return;
          setState(() {
            _loading = true;
            _loadError = null;
            _currentUrl = url;
            _syncUrlBar(url);
          });
        },
        onPageFinished: _onPageFinished,
        onNavigationRequest: (request) {
          if (_isDirectFileUrl(request.url)) {
            _downloadFile(request.url);
            return NavigationDecision.prevent;
          }
          // Only web pages load inside the WebView. A page cannot use an
          // intent://, file:// or content:// link to reach app-private data
          // or launch arbitrary components.
          final uri = Uri.tryParse(request.url);
          final scheme = uri?.scheme.toLowerCase();
          if (uri == null ||
              (scheme != 'http' && scheme != 'https' && scheme != 'about')) {
            return NavigationDecision.prevent;
          }
          // Google refuses OAuth/sign-in inside a WebView ("disallowed_useragent")
          // and the page just stalls. Hand those links to the system browser,
          // where the account flow actually works.
          if (_isGoogleSignInHost(uri.host)) {
            _openSignInExternally(request.url);
            return NavigationDecision.prevent;
          }
          // Top-level navigation to a known ad host never opens a page.
          if (BrowserBlockerService.instance.isBlockedUrl(request.url)) {
            BrowserBlockerService.instance.reportBlocked(1);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onWebResourceError: (error) {
          // Sub-resource errors (ads, trackers) are not a broken page.
          if (error.isForMainFrame == false) return;
          if (!mounted) return;
          setState(() {
            _loading = false;
            _progress = 0;
            _loadError = error.description;
          });
        },
      ));
  }

  void _onUrlBarChanged() {
    if (mounted) setState(() {});
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
    await _injectBlocker();
  }

  /// The WebView cannot filter sub-resources on its own, so the filter is a
  /// script injected as early as the document allows and re-applied after
  /// every page load (it removes nodes and hides the usual ad containers).
  Future<void> _injectBlocker({bool force = false}) async {
    final blocker = BrowserBlockerService.instance;
    if (!blocker.enabled && !force) return;
    try {
      await _web.runJavaScript(blocker.buildInjectionScript());
    } catch (e) {
      debugPrint('[Browser] blocker injection failed: $e');
    }
  }

  /// Google blocks its own sign-in inside embedded WebViews
  /// (`disallowed_useragent`), so the flow can only complete in the system
  /// browser. Pretending otherwise just left the user on a blank page.
  static bool _isGoogleSignInHost(String host) {
    final h = host.toLowerCase();
    return h == 'accounts.google.com' ||
        h.endsWith('.accounts.google.com') ||
        h == 'accounts.youtube.com';
  }

  Future<void> _openSignInExternally(String url) async {
    final loc = AppLocalizations.of(context);
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint('[Browser] external sign-in failed: ${e.runtimeType}');
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          opened ? loc.browserSignInExternal : loc.browserOpenFailed,
        ),
      ),
    );
  }

  void _syncUrlBar(String url) {
    if (_urlFocus.hasFocus) return;
    _urlBar.text = url;
  }

  bool _looksLikeUrl(String text) =>
      text.contains('://') ||
      (!text.contains(' ') && _hostLike.hasMatch(text));

  Uri? _resolveUri(String text) {
    if (_looksLikeUrl(text)) {
      final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
      if (uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https')) {
        return uri;
      }
    }
    return Uri.parse(
      'https://www.google.com/search?q=${Uri.encodeQueryComponent(text)}',
    );
  }

  /// Accepts a URL or free text: a URL opens the site, anything else becomes a
  /// web search. This is what makes the tab a real browser, not a YouTube app.
  void _navigate(String input) {
    final text = input.trim();
    if (text.isEmpty) return;
    _urlFocus.unfocus();
    _homeFocus.unfocus();
    final uri = _resolveUri(text);
    if (uri == null) return;
    _homeSearch.clear();
    setState(() => _showHome = false);
    _web.loadRequest(uri);
  }

  void _goHome() {
    _urlFocus.unfocus();
    _homeFocus.unfocus();
    setState(() => _showHome = true);
  }

  void _goBack() {
    if (_showHome) return;
    _web.goBack();
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

  bool _isDirectFileUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.pathSegments.isEmpty) return false;
    final name = uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return false;
    return _directFileExtensions.contains(
      name.substring(dot + 1).toLowerCase(),
    );
  }

  /// Downloads a link the page itself points at (pdf, zip, apk, plain media).
  /// The request is handled by the normal download manager: real progress,
  /// foreground notification and a file in the user's Downloads folder.
  void _downloadFile(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final loc = AppLocalizations.of(context);
    final rawName = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final name = Uri.decodeComponent(rawName);
    final dot = name.lastIndexOf('.');
    final ext = dot >= 0 ? name.substring(dot + 1).toLowerCase() : 'bin';
    final title = dot > 0 ? name.substring(0, dot) : name;
    context.read<DownloadsController>().addDirectFileDownload(
          url: url,
          title: title.isEmpty ? 'download' : title,
          fileExt: ext,
        );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(loc.browserDownloadStarted)),
    );
  }

  void _stopLoading() {
    // webview_flutter has no stopLoading() API. window.stop() is the web
    // standard way to abort the current document load and is supported by
    // the Android WebView.
    _web.runJavaScript('window.stop();');
    if (mounted) {
      setState(() {
        _loading = false;
        _progress = 0;
      });
    }
  }

  Future<void> _toggleDesktopMode() async {
    final next = !_desktopMode;
    setState(() => _desktopMode = next);
    await _web.setUserAgent(next ? _desktopUa : null);
    if (!_showHome) await _web.reload();
  }

  Future<void> _clearBrowsingData() async {
    final loc = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.browserClearData),
        content: Text(loc.browserClearDataConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _web.clearCache();
      await _web.clearLocalStorage();
      await WebViewCookieManager().clearCookies();
    } catch (_) {}
    if (!mounted) return;
    _urlBar.clear();
    _web.loadRequest(Uri.parse('about:blank'));
    _goHome();
  }

  @override
  void dispose() {
    _urlBar.removeListener(_onUrlBarChanged);
    _urlBar.dispose();
    _homeSearch.dispose();
    _urlFocus.dispose();
    _homeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final downloadable = _showHome ? null : _downloadable;
    final interceptBack = widget.isActive && !_showHome && _canGoBack;

    return PopScope(
      canPop: !interceptBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.isActive && !_showHome && _canGoBack) {
          _web.goBack();
        }
      },
      child: Stack(
      children: [
        SafeArea(
          top: true,
          bottom: false,
          child: Column(
          children: [
            _buildToolbar(cs, loc),
            if (_loading && !_showHome)
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 2,
              ),
            if (_loadError != null && !_showHome)
              _buildErrorBanner(cs, loc),
            Expanded(
              child: Stack(
                children: [
                  // Keep the WebView mounted behind the start page so the open
                  // tab is preserved when returning from a shortcut.
                  Positioned.fill(child: WebViewWidget(controller: _web)),
                  if (_showHome) _buildHome(context, loc, cs),
                ],
              ),
            ),
          ],
          ),
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
      ),
    );
  }

  Widget _buildErrorBanner(ColorScheme cs, AppLocalizations loc) {
    return Material(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded,
                size: 18, color: cs.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${loc.browserLoadError}: ${_loadError ?? ''}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: cs.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: () {
                final url = _currentUrl;
                if (url == null) return;
                setState(() => _loadError = null);
                _web.loadRequest(Uri.parse(url));
              },
              child: Text(loc.retry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(
    IconData icon, {
    VoidCallback? onPressed,
    String? tooltip,
  }) {
    return IconButton(
      icon: Icon(icon, size: 20),
      onPressed: onPressed,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      visualDensity: VisualDensity.compact,
    );
  }

  /// Discreet blocker indicator: the shield changes when the filter is off
  /// and shows how many requests it stopped.
  Widget _buildBlockerButton(ColorScheme cs, AppLocalizations loc) {
    return ListenableBuilder(
      listenable: BrowserBlockerService.instance,
      builder: (context, _) {
        final blocker = BrowserBlockerService.instance;
        final active = blocker.enabled;
        final count = blocker.blockedCount;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            _iconBtn(
              active ? Icons.shield : Icons.shield_outlined,
              tooltip: loc.browserBlocker,
              onPressed: () => _showBlockerSheet(),
            ),
            if (active && count > 0)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 9, height: 1.1),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _showBlockerSheet() async {
    final loc = AppLocalizations.of(context);
    final blocker = BrowserBlockerService.instance;
    await showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return ListenableBuilder(
          listenable: blocker,
          builder: (ctx, _) {
            final cs = Theme.of(ctx).colorScheme;
            final host = Uri.tryParse(_currentUrl ?? '')?.host ?? '';
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(blocker.enabled
                            ? Icons.shield
                            : Icons.shield_outlined),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(loc.browserBlocker,
                              style: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w700)),
                        ),
                        Switch(
                          value: blocker.enabled,
                          onChanged: (v) async {
                            await blocker.setEnabled(v);
                            // Re-run the script in both directions: it updates
                            // the live page (ENABLED flag, CSS, counter).
                            await _injectBlocker(force: true);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      blocker.enabled
                          ? loc.browserBlockerEnabled
                          : loc.browserBlockerDisabled,
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${loc.browserBlockerBlockedCount}: ${blocker.blockedCount}',
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    if (host.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () async {
                          await blocker.allowHost(host);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        icon: const Icon(Icons.add_link, size: 18),
                        label: Text('${loc.browserBlockerAllowSite}: $host'),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      loc.browserBlockerExceptions,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    if (blocker.allowedHosts.isEmpty)
                      Text(
                        loc.browserBlockerNoExceptions,
                        style: TextStyle(
                            color: cs.onSurfaceVariant, fontSize: 12),
                      )
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 160),
                        child: ListView(
                          shrinkWrap: true,
                          children: blocker.allowedHosts.map((h) {
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(h, style: const TextStyle(fontSize: 13)),
                              trailing: IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () => blocker.disallowHost(h),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildToolbar(ColorScheme cs, AppLocalizations loc) {    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            _iconBtn(
              Icons.arrow_back_rounded,
              tooltip: loc.back,
              onPressed: _canGoBack ? _goBack : null,
            ),
            _iconBtn(
              Icons.arrow_forward_rounded,
              onPressed: _canGoForward ? () => _web.goForward() : null,
            ),
            _iconBtn(
              Icons.home_rounded,
              tooltip: loc.navHome,
              onPressed: _showHome ? null : _goHome,
            ),
            const SizedBox(width: 2),
            Expanded(
              child: TextField(
                controller: _urlBar,
                focusNode: _urlFocus,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                onSubmitted: _navigate,
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
            const SizedBox(width: 2),
            _buildBlockerButton(cs, loc),
            _iconBtn(
              _loading ? Icons.close_rounded : Icons.refresh_rounded,
              tooltip: _loading ? loc.browserStop : loc.retry,
              onPressed: _showHome
                  ? null
                  : (_loading ? _stopLoading : () => _web.reload()),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              onSelected: (action) async {
                switch (action) {
                  case 'home':
                    _goHome();
                    break;
                  case 'external':
                    final url = _currentUrl;
                    if (url != null) {
                      final opened = await launchUrl(Uri.parse(url),
                          mode: LaunchMode.externalApplication);
                      if (!opened && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(loc.browserOpenFailed)),
                        );
                      }
                    }
                    break;
                  case 'desktop':
                    await _toggleDesktopMode();
                    break;
                  case 'clear':
                    await _clearBrowsingData();
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
                PopupMenuItem(
                  value: 'desktop',
                  child: Row(children: [
                    Icon(
                      _desktopMode
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Text(loc.browserDesktopSite),
                  ]),
                ),
                PopupMenuItem(
                  value: 'clear',
                  child: Row(children: [
                    const Icon(Icons.cleaning_services_outlined, size: 18),
                    const SizedBox(width: 10),
                    Text(loc.browserClearData),
                  ]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHome(BuildContext context, AppLocalizations loc, ColorScheme cs) {
    final tt = Theme.of(context).textTheme;
    return Material(
      color: cs.surface,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF7C4DFF), Color(0xFF448AFF)],
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.explore_rounded,
                      color: Colors.white, size: 25),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loc.navBrowser,
                        style: tt.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        loc.browserTagline,
                        style: tt.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildSearchField(cs, loc),
            const SizedBox(height: 24),
            Text(
              loc.browserPopularSites.toUpperCase(),
              style: tt.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 0.82,
              children: [
                for (final site in _sites) _buildSiteCard(context, site),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField(ColorScheme cs, AppLocalizations loc) {
    return TextField(
      controller: _homeSearch,
      focusNode: _homeFocus,
      keyboardType: TextInputType.webSearch,
      textInputAction: TextInputAction.search,
      onSubmitted: _navigate,
      style: const TextStyle(fontSize: 14.5),
      decoration: InputDecoration(
        hintText: loc.browserUrlHint,
        hintStyle: TextStyle(
          color: cs.onSurfaceVariant.withValues(alpha: 0.6),
        ),
        prefixIcon: Icon(Icons.search_rounded,
            size: 20, color: cs.onSurfaceVariant),
        suffixIcon: IconButton(
          icon: Icon(Icons.arrow_forward_rounded, size: 18, color: cs.primary),
          onPressed: () => _navigate(_homeSearch.text),
        ),
        filled: true,
        fillColor: cs.surfaceContainerHighest,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildSiteCard(BuildContext context, _BrowserSite site) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _navigate(site.url),
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: site.colors,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: site.colors.first.withValues(alpha: 0.32),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: site.glyph != null
                    ? Text(
                        site.glyph!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          height: 1,
                          fontWeight: FontWeight.w800,
                        ),
                      )
                    : Icon(site.icon, color: Colors.white, size: 20),
              ),
              const SizedBox(height: 8),
              Text(
                site.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
