import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibegrab/services/browser_blocker_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final blocker = BrowserBlockerService.instance;
    await blocker.init();
    blocker.resetCount();
    await blocker.setEnabled(true);
    for (final host in blocker.allowedHosts.toList()) {
      await blocker.disallowHost(host);
    }
  });

  group('host matching', () {
    test('matches the host itself and its sub-domains', () {
      expect(
        BrowserBlockerService.hostMatches('doubleclick.net', 'doubleclick.net'),
        isTrue,
      );
      expect(
        BrowserBlockerService.hostMatches(
            'ads.example.doubleclick.net', 'doubleclick.net'),
        isTrue,
      );
      expect(
        BrowserBlockerService.hostMatches('notdoubleclick.net', 'doubleclick.net'),
        isFalse,
      );
      expect(
        BrowserBlockerService.hostMatches('doubleclick.net.evil.com',
            'doubleclick.net'),
        isFalse,
      );
    });
  });

  group('blocked urls', () {
    test('a known ad host is blocked', () {
      final blocker = BrowserBlockerService.instance;
      expect(
        blocker.isBlockedUrl(
            'https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js'),
        isTrue,
      );
      expect(
        blocker.isBlockedUrl('https://ib.adnxs.com/get?cid=1'),
        isTrue,
      );
      expect(
        blocker.isBlockedUrl('https://stats.g.doubleclick.net/collect'),
        isTrue,
      );
    });

    test('a normal site is not blocked', () {
      final blocker = BrowserBlockerService.instance;
      expect(blocker.isBlockedUrl('https://www.youtube.com/watch?v=abc'), isFalse);
      expect(blocker.isBlockedUrl('https://example.com/video.mp4'), isFalse);
      expect(blocker.isBlockedUrl('not a url'), isFalse);
    });

    test('an exception always wins over the rules', () async {
      final blocker = BrowserBlockerService.instance;
      await blocker.allowHost('googlesyndication.com');
      expect(
        blocker.isBlockedUrl('https://pagead2.googlesyndication.com/x.js'),
        isFalse,
      );
      await blocker.disallowHost('googlesyndication.com');
      expect(
        blocker.isBlockedUrl('https://pagead2.googlesyndication.com/x.js'),
        isTrue,
      );
    });

    test('the blocker can be switched off', () async {
      final blocker = BrowserBlockerService.instance;
      await blocker.setEnabled(false);
      expect(
          blocker.isBlockedUrl('https://pagead2.googlesyndication.com/x.js'),
          isFalse);
      await blocker.setEnabled(true);
      expect(
          blocker.isBlockedUrl('https://pagead2.googlesyndication.com/x.js'),
          isTrue);
    });
  });

  group('injection script', () {
    test('carries the rules and the cosmetic scrubber', () {
      final blocker = BrowserBlockerService.instance;
      final script = blocker.buildInjectionScript();
      expect(script.contains('googlesyndication.com'), isTrue);
      expect(script.contains('MutationObserver'), isTrue);
      expect(script.contains('vibegrab-blocker-style'), isTrue);
      expect(script.contains('ins.adsbygoogle'), isTrue);
    });

    test('does not pretend to be a network filter from JavaScript', () {
      final blocker = BrowserBlockerService.instance;
      final script = blocker.buildInjectionScript();
      // The real block happens in shouldInterceptRequest. Hooking fetch/XHR
      // from the page would only hide requests that already left the app.
      expect(script.contains('window.fetch'), isFalse);
      expect(script.contains('XMLHttpRequest.prototype.open'), isFalse);
      expect(script.contains('callHandler'), isFalse);
    });

    test('the script carries the enabled flag and a real kill switch', () async {
      final blocker = BrowserBlockerService.instance;
      await blocker.setEnabled(true);
      expect(blocker.buildInjectionScript().contains('var ENABLED = true'),
          isTrue);

      await blocker.setEnabled(false);
      final disabled = blocker.buildInjectionScript();
      expect(disabled.contains('var ENABLED = false'), isTrue);
      expect(disabled.contains('removeStyle'), isTrue);
      // Leave the shared singleton enabled for the rest of the suite.
      await blocker.setEnabled(true);
    });
  });

  group('blocked counter', () {
    test('one report per intercepted request adds up', () {
      final blocker = BrowserBlockerService.instance;
      blocker.resetCount();

      blocker.reportBlocked();
      blocker.reportBlocked();
      blocker.reportBlocked();
      expect(blocker.blockedCount, 3);

      blocker.reportBlocked(4);
      expect(blocker.blockedCount, 7);

      blocker.resetCount();
      expect(blocker.blockedCount, 0);
    });

    test('a non-positive report changes nothing', () {
      final blocker = BrowserBlockerService.instance;
      blocker.resetCount();
      blocker.reportBlocked(0);
      blocker.reportBlocked(-2);
      expect(blocker.blockedCount, 0);
    });
  });
}
