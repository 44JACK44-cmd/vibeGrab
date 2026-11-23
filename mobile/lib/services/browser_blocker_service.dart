import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ad/tracker blocker for the built-in browser.
///
/// HOW IT WORKS
///
/// The browser uses `flutter_inappwebview` (Android WebView). Its
/// `shouldInterceptRequest` hook sees every sub-resource before Chromium
/// requests it, so the block is real and network-level:
///
///  * A request whose host is on [defaultBlockedHosts] (and is not covered by
///    a per-site exception) is answered with an empty response. The page never
///    contacts the ad server.
///  * Top-level navigations to a blocked host are cancelled in
///    `shouldOverrideUrlLoading`, so ad redirects never open a page.
///  * A document-start script removes `<script>`/`<iframe>`/`<img>` nodes that
///    point at blocked hosts and hides the usual ad containers with CSS. This
///    is cosmetic: it keeps empty ad slots from breaking the layout.
///
/// LIMITATIONS: same-origin ads (served from the site's own domain) are not
/// detected, and a site that hard-codes an ad URL into its first HTML response
/// is still covered because interception happens before the request, not after
/// the response. The filter is a blocklist, not a guarantee.
class BrowserBlockerService extends ChangeNotifier {
  static final BrowserBlockerService instance = BrowserBlockerService._();
  BrowserBlockerService._();

  static const _enabledKey = 'vibegrab_blocker_enabled';
  static const _allowKey = 'vibegrab_blocker_allowed_hosts';

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
        ..addAll(allowed
            .map((h) => h.trim().toLowerCase())
            .where((h) => h.isNotEmpty));
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

  /// Called by the WebView's request interceptor. One call per blocked
  /// sub-resource, so the badge shows real network blocks.
  void reportBlocked([int count = 1]) {
    if (count <= 0) return;
    _blockedCount += count;
    notifyListeners();
  }

  void resetCount() {
    if (_blockedCount == 0) return;
    _blockedCount = 0;
    notifyListeners();
  }

  /// Cosmetic half of the blocker. It is injected at document start and
  /// re-applied after every page load (and when the user toggles the switch).
  /// Network blocking happens in `shouldInterceptRequest`; this script only
  /// removes the leftover nodes and hides empty ad containers.
  String buildInjectionScript() {
    final rules = jsonEncode(defaultBlockedHosts.toList());
    final allow = jsonEncode(_allowedHosts.toList());
    final selectors = jsonEncode(defaultHiddenSelectors.toList());
    final enabled = _enabled ? 'true' : 'false';
    return '''
(function () {
  var RULES = $rules;
  var ALLOW = $allow;
  var SELECTORS = $selectors;
  var ENABLED = $enabled;
  if (window.__vibeGrabBlocker) {
    window.__vibeGrabBlocker.update(RULES, ALLOW, ENABLED);
    return;
  }
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
    if (!ENABLED) return false;
    var h = hostOf(url);
    if (!h) return false;
    if (matches(h, ALLOW)) return false;
    return matches(h, RULES);
  }
  function injectStyle() {
    if (!ENABLED) return;
    if (document.getElementById('vibegrab-blocker-style')) return;
    var root = document.head || document.documentElement;
    if (!root) return;
    var style = document.createElement('style');
    style.id = 'vibegrab-blocker-style';
    style.textContent = SELECTORS.join(',') + '{display:none !important;}';
    root.appendChild(style);
  }
  function removeStyle() {
    var style = document.getElementById('vibegrab-blocker-style');
    if (style) style.remove();
  }
  function scrub() {
    if (!ENABLED) return;
    var nodes = document.querySelectorAll('script[src],iframe[src],img[src],source[src],video[src],link[href]');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var u = el.getAttribute('src') || el.getAttribute('href');
      if (u && blocked(u)) { el.remove(); }
    }
  }
  try {
    var mo = new MutationObserver(function () { scrub(); });
    mo.observe(document, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src', 'href']
    });
  } catch (e) {}
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      injectStyle();
      scrub();
    });
  } else {
    injectStyle();
    scrub();
  }
  window.__vibeGrabBlocker = {
    update: function (newRules, newAllow, newEnabled) {
      RULES = newRules;
      ALLOW = newAllow;
      ENABLED = !!newEnabled;
      if (!ENABLED) { removeStyle(); } else { injectStyle(); scrub(); }
    }
  };
})();
true;
''';
  }
}
