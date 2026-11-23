import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/services/browser_playback_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = BrowserPlaybackService.instance;
  final sources = <String>[];

  setUp(() async {
    sources.clear();
    service.detach();
    await service.release();
    service.attach((source) async {
      sources.add(source);
    });
  });

  tearDown(() async {
    service.detach();
    await service.release();
  });

  test('playing media starts the native service', () async {
    await service.onMediaState(playing: true);
    expect(service.playing, isTrue);
    // A unit test has no Android implementation, so the channel call is
    // reported as missing and the service must not be marked as running.
    expect(service.serviceRunning, isFalse);
  });

  test('holds the page only while something is playing', () async {
    await service.onMediaState(playing: true);
    await service.onAppInactive();
    expect(service.holding, isTrue);
    expect(sources, contains(BrowserPlaybackService.setAwayOn));

    await service.onAppResumed();
    expect(service.holding, isFalse);
    expect(sources, contains(BrowserPlaybackService.setAwayOff));
  });

  test('an idle page is never held', () async {
    await service.onAppInactive();
    expect(service.holding, isFalse);
    expect(sources, isEmpty);
  });

  test('ended playback clears the hold', () async {
    await service.onMediaState(playing: true);
    await service.onAppInactive();
    expect(service.holding, isTrue);

    await service.onMediaState(playing: false, ended: true);
    expect(service.playing, isFalse);
    expect(service.holding, isFalse);
  });

  test('a foreground pause releases the service', () async {
    await service.onMediaState(playing: true);
    await service.onMediaState(playing: false);
    expect(service.playing, isFalse);
    expect(service.holding, isFalse);
  });

  test('the install script guards visibility and pauses', () {
    const script = BrowserPlaybackService.installScript;
    expect(script.contains('visibilityState'), isTrue);
    expect(script.contains('__vibeGrabSetAway'), isTrue);
    expect(script.contains('VibeGrabMedia'), isTrue);
    // The pause guard must depend on being away, not on playback alone:
    // otherwise the user could not pause from the page.
    expect(script.contains('__vibeGrabAway && !allowedPause()'), isTrue);
  });
}
