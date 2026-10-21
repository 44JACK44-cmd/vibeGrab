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
  });
}
