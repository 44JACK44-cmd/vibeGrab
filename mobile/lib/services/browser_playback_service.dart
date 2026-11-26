import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps HTML5 audio/video playing when VibeGrab leaves the foreground or the
/// screen turns off.
///
/// Android pauses Chromium's media when the WebView window is no longer
/// visible, and many sites pause themselves on `visibilitychange`. This class
/// coordinates the two halves that make background playback work:
///
///  * [installScript] runs at document start in every frame. While a media
///    element is actually playing it reports `document.visibilityState` as
///    `visible` and swallows the page's `visibilitychange`/`blur`/`pagehide`
///    handlers. Only while the app is away does it also ignore the page's
///    `pause()` calls, so the user can still pause normally in the foreground.
///  * A native `mediaPlayback` foreground service with a partial wake lock
///    keeps the process alive while the screen is off. It is started as soon
///    as playback begins (the app is still in the foreground then, which is
///    what Android 12+ requires to start a foreground service).
///
/// The picture stops with the window (Android does not render an invisible
/// WebView); audio continues from the same position.
class BrowserPlaybackService extends ChangeNotifier {
  BrowserPlaybackService._();

  static final BrowserPlaybackService instance = BrowserPlaybackService._();

  static const MethodChannel _channel =
      MethodChannel('com.example.vibegrab/browser_playback');

  /// JS handler the page script calls with `{playing, ended, title, url}`.
  static const String handlerName = 'VibeGrabMedia';

  /// Runs at document start, in every frame.
  static const String installScript = r'''
(function () {
  if (window.__vibeGrabMediaInstalled) return;
  window.__vibeGrabMediaInstalled = true;
  window.__vibeGrabVisibleHold = false;
  window.__vibeGrabAway = false;
  window.__vibeGrabAllowPauseUntil = 0;
  window.__vibeGrabHeld = [];

  var known = [];
  function track(el) {
    if (el && known.indexOf(el) < 0) known.push(el);
  }
  function visibleHeld() {
    return !!window.__vibeGrabVisibleHold || !!window.__vibeGrabAway;
  }
  function allowedPause() {
    return Date.now() < (window.__vibeGrabAllowPauseUntil || 0);
  }
  function snapshot() {
    var playing = false;
    var ended = false;
    for (var i = 0; i < known.length; i++) {
      var el = known[i];
      if (!el) continue;
      if (el.ended) { ended = true; continue; }
      if (!el.paused) playing = true;
    }
    if (playing) ended = false;
    window.__vibeGrabVisibleHold = playing;
    return { playing: playing, ended: ended };
  }
  function report() {
    var state = snapshot();
    try {
      var artist = '';
      try {
        var meta = document.querySelector('meta[name="artist"]');
        if (meta && meta.content) artist = meta.content.toString();
      } catch (e) {}
      window.flutter_inappwebview.callHandler('VibeGrabMedia', {
        playing: state.playing,
        ended: state.ended,
        title: document.title || '',
        artist: artist,
        url: location.href
      });
    } catch (e) {}
  }

  // 1. Keep the document "visible" while a media element is playing. This is
  //    what stops sites (YouTube included) from pausing on visibilitychange.
  var hiddenDesc = Object.getOwnPropertyDescriptor(Document.prototype, 'hidden');
  var visDesc =
      Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState');
  try {
    Object.defineProperty(document, 'hidden', {
      configurable: true,
      get: function () {
        if (visibleHeld()) return false;
        try {
          return hiddenDesc && hiddenDesc.get
              ? hiddenDesc.get.call(document)
              : false;
        } catch (e) { return false; }
      }
    });
  } catch (e) {}
  try {
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: function () {
        if (visibleHeld()) return 'visible';
        try {
          return visDesc && visDesc.get
              ? visDesc.get.call(document)
              : 'visible';
        } catch (e) { return 'visible'; }
      }
    });
  } catch (e) {}

  function swallow(e) {
    if (visibleHeld()) e.stopImmediatePropagation();
  }
  document.addEventListener('visibilitychange', swallow, true);
  document.addEventListener('webkitvisibilitychange', swallow, true);
  window.addEventListener('blur', swallow, true);
  window.addEventListener('pagehide', swallow, true);

  // 2. Ignore page-initiated pauses only while the app is away. A pause from
  //    the user (the app is visible) still works normally.
  var proto = window.HTMLMediaElement && HTMLMediaElement.prototype;
  if (proto && !proto.__vibeGrabPause) {
    var origPause = proto.pause;
    var origPlay = proto.play;
    proto.__vibeGrabPause = true;
    proto.play = function () {
      var result = origPlay.apply(this, arguments);
      track(this);
      setTimeout(report, 0);
      return result;
    };
    proto.pause = function () {
      if (window.__vibeGrabAway && !allowedPause()) return;
      var result = origPause.apply(this, arguments);
      setTimeout(report, 0);
      return result;
    };
  }

  // 3. Track every media element, including the ones created after load.
  ['playing', 'pause', 'ended', 'emptied', 'waiting'].forEach(function (name) {
    document.addEventListener(name, function (e) {
      var el = e.target;
      if (!el || !el.tagName || !/^(AUDIO|VIDEO)$/.test(el.tagName)) return;
      track(el);
      report();
      if (name === 'ended') autoAdvance();
    }, true);
  });

  // 5. When the element the page is playing ends, pass to the next one.
  // Many sites (Youtube, Tiktok) already do this natively; this covers the
  // ones that stop at the end: the user does not have to press Play again.
  function autoAdvance() {
    for (var i = 0; i < known.length; i++) {
      var el = known[i];
      if (!el || el.ended || !el.paused) continue;
      try {
        var p = el.play();
        if (p && p.catch) p.catch(function () {});
      } catch (e) {}
      break;
    }
  }

  // 4. Called by Dart when the app goes away: remember what was playing and
  //    resume anything the page paused just before the flag was installed.
  window.__vibeGrabSetAway = function (away) {
    window.__vibeGrabAway = !!away;
    if (!away) {
      window.__vibeGrabHeld = [];
      return;
    }
    window.__vibeGrabHeld = [];
    for (var i = 0; i < known.length; i++) {
      var el = known[i];
      if (el && !el.paused && !el.ended) window.__vibeGrabHeld.push(el);
    }
    setTimeout(function () {
      for (var j = 0; j < window.__vibeGrabHeld.length; j++) {
        var el = window.__vibeGrabHeld[j];
        if (el && el.paused && !el.ended) {
          try {
            var p = el.play();
            if (p && p.catch) p.catch(function () {});
          } catch (e) {}
        }
      }
      report();
    }, 0);
  };

  report();
})();
true;
''';

  /// The app lost the foreground: swallow pauses and resume what was playing.
  static const String setAwayOn = 'if(window.__vibeGrabSetAway)'
      'window.__vibeGrabSetAway(true);';

  /// The app is visible again: normal pause/visibility behaviour comes back.
  static const String setAwayOff = 'if(window.__vibeGrabSetAway)'
      'window.__vibeGrabSetAway(false);';

  Future<void> Function(String source)? _evaluate;
  bool _playing = false;
  bool _holding = false;
  bool _serviceRunning = false;

  bool get playing => _playing;
  bool get holding => _holding;
  bool get serviceRunning => _serviceRunning;

  /// The browser view provides the `evaluateJavascript` entry point.
  void attach(Future<void> Function(String source) evaluate) {
    _evaluate = evaluate;
  }

  void detach() {
    _evaluate = null;
  }

  /// Called from the page's `VibeGrabMedia` handler.
  ///
  /// The foreground service is started here, while the app is still in the
  /// foreground: Android 12+ rejects starting one from the background.
  Future<void> onMediaState({
    required bool playing,
    bool ended = false,
  }) async {
    if (ended) {
      _playing = false;
      _holding = false;
      notifyListeners();
      await _stopService();
      return;
    }
    if (_playing == playing) return;
    _playing = playing;
    if (playing) {
      await _startService();
    } else if (!_holding) {
      // A pause in the foreground means the user stopped: no service needed.
      // While holding, keep it: the hold may resume the element.
      await _stopService();
    }
    notifyListeners();
  }

  /// The app lost the foreground (screen off, app switch, notification
  /// shade). Only holds when something is actually playing: an idle page
  /// keeps the normal pause path.
  Future<void> onAppInactive() async {
    if (!_playing || _holding) return;
    _holding = true;
    notifyListeners();
    final evaluate = _evaluate;
    if (evaluate != null) {
      try {
        await evaluate(setAwayOn);
      } catch (e) {
        debugPrint('[BrowserPlayback] hold failed: $e');
      }
    }
    if (!_serviceRunning) await _startService();
  }

  /// The app is visible again: stop pretending and let the user pause. If
  /// playback already ended while away, drop the foreground service too.
  Future<void> onAppResumed() async {
    if (_holding) {
      _holding = false;
      notifyListeners();
      final evaluate = _evaluate;
      if (evaluate != null) {
        try {
          await evaluate(setAwayOff);
        } catch (e) {
          debugPrint('[BrowserPlayback] release failed: $e');
        }
      }
    }
    if (!_playing) await _stopService();
  }

  /// The browser view is going away: clear the hold and the service.
  Future<void> release() async {
    _playing = false;
    final wasHolding = _holding;
    _holding = false;
    if (wasHolding) {
      final evaluate = _evaluate;
      if (evaluate != null) {
        try {
          await evaluate(setAwayOff);
        } catch (e) {
          debugPrint('[BrowserPlayback] release failed: $e');
        }
      }
    }
    await _stopService();
    notifyListeners();
  }

  Future<void> _startService() async {
    if (_serviceRunning) return;
    try {
      final started = await _channel.invokeMethod<bool>('start');
      _serviceRunning = started ?? false;
    } on PlatformException catch (e) {
      // Android 12+ can reject a foreground service started from the
      // background. The media keeps playing if the process survives; the
      // error is reported instead of pretending the service is running.
      debugPrint('[BrowserPlayback] start failed: ${e.code} ${e.message}');
    } on MissingPluginException {
      // Non-Android platforms (tests/desktop) have no native service.
    }
  }

  Future<void> _stopService() async {
    if (!_serviceRunning) return;
    _serviceRunning = false;
    try {
      await _channel.invokeMethod<bool>('stop');
    } on PlatformException catch (e) {
      debugPrint('[BrowserPlayback] stop failed: ${e.code} ${e.message}');
    } on MissingPluginException {
      // Non-Android platforms (tests/desktop) have no native service.
    }
  }
}
