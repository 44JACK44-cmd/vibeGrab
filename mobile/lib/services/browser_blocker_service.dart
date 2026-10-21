import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Selective third-party ad/tracker blocker for the built-in browser.
///
/// HOW IT WORKS (and what it cannot do)
///
/// The browser uses `webview_flutter` (Android WebView). That WebView does
/// NOT expose a request-interception hook for sub-resources, so a real
/// network-level filter (like a VPN/hosts-file block) is not possible here.
/// What this service does instead, and does honestly:
///
///  * Top-level navigations to a blocked host are stopped in Dart
///    (`NavigationRequest`), so ad redirects never open a page.
///  * After every page load a small script is injected that aborts
///    `fetch` / `XMLHttpRequest` / `WebSocket` / `sendBeacon` calls whose URL
///    matches a blocked host, removes `<script>`/`<iframe>`/`<img>` nodes
///    pointing at those hosts and hides well-known ad containers with CSS.
///  * The user can turn the blocker off and can allow a site explicitly
///    (exceptions always win over the rules).
///
/// LIMITATIONS: resources that the FIRST HTML response already contains are
/// requested before the script can run, and ads served from the same origin as
/// the content are not detected. This is a filter, not a guarantee.
class BrowserBlockerService extends ChangeNotifier {
  static final BrowserBlockerService instance = BrowserBlockerService._();
  BrowserBlockerService._();

  static const _enabledKey = 'vibegrab_blocker_enabled';
  static const _allowKey = 'vibegrab_blocker_allowed_hosts';

  /// Name of the JavaScript channel the injected script uses to report the
  /// requests it blocked.
  static const channelName = 'VibeGrabBlocker';

  /// Host names of well-known advertising networks. Sub-domains are covered
  /// automatically (`ads.example.doubleclick.net` matches `doubleclick.net`).
  static const defaultBlockedHosts = <String>{
    // Google / DoubleClick
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'googletagservices.com',
    'adservice.google.com',
    '2mdn.net',
    // Programmatic exchanges
    'adnxs.com',
    'adsrvr.org',
    'adform.net',
    'ad-delivery.net',
    'advertising.com',
    'appnexus.com',
    'bidswitch.net',
    'casalemedia.com',
    'contextweb.com',
    'criteo.com',
    'criteo.net',
    'emxdgt.com',
    'exoclick.com',
    'fadsrvr.com',
    'gumgum.com',
    'indexww.com',
    'lijit.com',
    'media.net',
    'mgid.com',
    'moatads.com',
    'openx.net',
    'outbrain.com',
    'pubmatic.com',
    'revcontent.com',
    'rubiconproject.com',
    'sharethrough.com',
    'smartadserver.com',
    'sogoucdn.com',
    'taboola.com',
    'teads.tv',
    'themoneytizer.com',
    'tripleclick.com',
    'yieldmo.com',
    'zedo.com',
    // Common ad / pop networks
    'adcash.com',
    'adsterra.com',
    'exosrv.com',
    'hilltopads.net',
    'popads.net',
    'popcash.net',
    'propellerads.com',
    'adskeeper.com',
    'admitad.com',
    // Trackers
    'adroll.com',
    'bluekai.com',
    'chartbeat.com',
    'crwdcntrl.net',
    'demdex.net',
    'doubleclick.com',
    'fullstory.com',
    'google-analytics.com',
    'hotjar.com',
    'mixpanel.com',
    'omtrdc.net',
    'quantserve.com',
    'rlcdn.com',
    'scorecardresearch.com',
    'segment.io',
    'stats.g.doubleclick.net',
    '33across.com',
  };

  /// CSS selectors of the containers that hold most in-page ads. They are
  /// hidden, not removed, so the page keeps its layout.
  static const defaultHiddenSelectors = <String>[
    'ins.adsbygoogle',
    '[id^="google_ads_"]',
    '[id^="div-gpt-ad"]',
    '[id^="banner-ad"]',
    '[id^="ad-container"]',
    '[id^="ad-slot"]',
    '[id^="ad_wrapper"]',
    '[id^="ad-unit"]',
    '[id^="adsbox"]',
    '.adsbygoogle',
    '.ad-container',
    '.ad-wrapper',
    '.advertisement',
    '.ad-placement',
    '.banner-ad',
    '.taboola-container',
    '.outbrain-container',
    'iframe[src*="doubleclick.net"]',
    'iframe[src*="googlesyndication.com"]',
    'iframe[src*="adservice.google"]',
    'iframe[src*="adnxs.com"]',
  ];

  bool _enabled = true;
  bool get enabled => _enabled;

  final Set<String> _allowedHosts = <String>{};
  Set<String> get allowedHosts => Set.unmodifiable(_allowedHosts);

  int _blockedCount = 0;
  int get blockedCount => _blockedCount;

  bool _loaded = false;

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_enabledKey) ?? true;
      final allowed = prefs.getStringList(_allowKey) ?? const <String>[];
      _allowedHosts
        ..clear()
        ..addAll(allowed.map((h) => h.trim().toLowerCase()).where((h) => h.isNotEmpty));
    } catch (_) {
      _enabled = true;
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, value);
    } catch (_) {}
  }

  /// Adds an exception: this site is always allowed, even if one of its
  /// resources is on a blocked list.
  Future<void> allowHost(String host) async {
    final clean = host.trim().toLowerCase();
    if (clean.isEmpty) return;
    _allowedHosts.add(clean);
    notifyListeners();
    await _persistAllowed();
  }

  Future<void> disallowHost(String host) async {
    if (_allowedHosts.remove(host.trim().toLowerCase())) {
      notifyListeners();
      await _persistAllowed();
    }
  }

  Future<void> _persistAllowed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_allowKey, _allowedHosts.toList());
    } catch (_) {}
  }

  /// Host match used by every rule: exact host or a sub-domain of it.
  static bool hostMatches(String host, String rule) {
    final h = host.trim().toLowerCase();
    final r = rule.trim().toLowerCase();
    if (h.isEmpty || r.isEmpty) return false;
    if (h == r) return true;
    return h.endsWith('.$r');
  }

  /// True when [url] points at a blocked host and no exception allows it.
  bool isBlockedUrl(String url) {
    if (!_enabled) return false;
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    for (final allowed in _allowedHosts) {
      if (hostMatches(host, allowed)) return false;
    }
    for (final rule in defaultBlockedHosts) {
      if (hostMatches(host, rule)) return true;
    }
    return false;
  }

  void reportBlocked(int count) {
    if (count <= 0) return;
    _blockedCount += count;
    notifyListeners();
  }

  void resetCount() {
    if (_blockedCount == 0) return;
    _blockedCount = 0;
    notifyListeners();
  }

  /// The script injected after every page load. It is self-contained: the
  /// rules travel with it so the page never has to ask Dart.
  String buildInjectionScript() {
    final rules = jsonEncode(defaultBlockedHosts.toList());
    final allow = jsonEncode(_allowedHosts.toList());
    final selectors = jsonEncode(defaultHiddenSelectors.toList());
    return '''
(function () {
  if (window.__vibeGrabBlocker) { window.__vibeGrabBlocker.update($rules, $allow); return; }
  var RULES = $rules;
  var ALLOW = $allow;
  var SELECTORS = $selectors;
  var count = 0;

  function hostOf(u) {
    try { return new URL(u, location.href).hostname.toLowerCase(); } catch (e) { return ''; }
  }
  function matches(host, list) {
    for (var i = 0; i < list.length; i++) {
      var r = list[i];
      if (host === r) return true;
      if (host.length > r.length && host.slice(-(r.length + 1)) === '.' + r) return true;
    }
    return false;
  }
  function blocked(url) {
    var h = hostOf(url);
    if (!h) return false;
    if (matches(h, ALLOW)) return false;
    return matches(h, RULES);
  }
  function report() {
    try { window.VibeGrabBlocker.postMessage(String(count)); } catch (e) {}
  }
  function note() { count++; report(); }

  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function (input, init) {
      var url = (typeof input === 'string') ? input : (input && input.url);
      if (url && blocked(url)) { note(); return Promise.reject(new TypeError('blocked by VibeGrab')); }
      return origFetch.apply(this, arguments);
    };
  }

  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    if (url && blocked(url)) { note(); throw new DOMException('blocked by VibeGrab', 'NetworkError'); }
    return origOpen.apply(this, arguments);
  };

  var OrigWS = window.WebSocket;
  if (OrigWS) {
    var WSProxy = function (url, protocols) {
      if (url && blocked(url)) { note(); throw new Error('blocked by VibeGrab'); }
      return new OrigWS(url, protocols);
    };
    WSProxy.prototype = OrigWS.prototype;
    window.WebSocket = WSProxy;
  }

  if (navigator.sendBeacon) {
    var origBeacon = navigator.sendBeacon.bind(navigator);
    navigator.sendBeacon = function (url, data) {
      if (url && blocked(url)) { note(); return false; }
      return origBeacon(url, data);
    };
  }

  function scrub() {
    var nodes = document.querySelectorAll('script[src],iframe[src],img[src],source[src],video[src],link[href]');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var u = el.getAttribute('src') || el.getAttribute('href');
      if (u && blocked(u)) { note(); el.remove(); }
    }
  }

  function injectStyle() {
    if (document.getElementById('vibegrab-blocker-style')) return;
    var style = document.createElement('style');
    style.id = 'vibegrab-blocker-style';
    style.textContent = SELECTORS.join(',') + '{display:none !important;}';
    (document.head || document.documentElement).appendChild(style);
  }

  try {
    var mo = new MutationObserver(function () { scrub(); });
    mo.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'href'] });
  } catch (e) {}

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { injectStyle(); scrub(); });
  } else { injectStyle(); scrub(); }

  window.__vibeGrabBlocker = {
    count: function () { return count; },
    update: function (newRules, newAllow) {
      RULES = newRules; ALLOW = newAllow; count = 0; report();
    }
  };
  report();
})();
true;
''';
  }
}
