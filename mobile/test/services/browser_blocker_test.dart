import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibegrab/services/browser_blocker_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
        blocker.isBlockedUrl('https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js'),
        isTrue,
      );
      expect(
        blocker.isBlockedUrl('https://ib.adnxs.com/get?cid=1'),
        isTrue,
      );
    });

    test('a normal site is not blocked', () async {
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
    test('carries the rules, the exceptions and the hooks', () {
      final blocker = BrowserBlockerService.instance;
      final script = blocker.buildInjectionScript();
      expect(script.contains('googlesyndication.com'), isTrue);
      expect(script.contains('window.fetch'), isTrue);
      expect(script.contains('XMLHttpRequest.prototype.open'), isTrue);
      expect(script.contains('MutationObserver'), isTrue);
      expect(script.contains(BrowserBlockerService.channelName), isTrue);
    });

    test('the report is JSON with a session id and a cumulative count', () {
      final script = BrowserBlockerService.instance.buildInjectionScript();
      expect(script.contains('JSON.stringify({ id: SESSION, count: count })'),
          isTrue);
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
    test('cumulative reports for one page add only the delta', () {
      final blocker = BrowserBlockerService.instance;
      blocker.resetCount();

      blocker.reportBlocked(1, session: 'page-1');
      blocker.reportBlocked(1, session: 'page-1');
      blocker.reportBlocked(4, session: 'page-1');
      expect(blocker.blockedCount, 4);

      // A new document restarts the counter: its first report is all new.
      blocker.reportBlocked(2, session: 'page-2');
      expect(blocker.blockedCount, 6);

      blocker.resetCount();
      expect(blocker.blockedCount, 0);
    });

    test('a restarted counter inside the same session is a delta from zero',
        () {
      final blocker = BrowserBlockerService.instance;
      blocker.resetCount();

      blocker.reportBlocked(5, session: 'page');
      // update() resets the script's count; the next report is 2 new blocks.
      blocker.reportBlocked(2, session: 'page');
      expect(blocker.blockedCount, 7);
      blocker.resetCount();
    });
  });
}
