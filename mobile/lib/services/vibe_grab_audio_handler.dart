import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'session_snapshot.dart';

abstract class MediaEngineDelegate {
  AudioPlayer get audioPlayer;
  SessionSnapshot get currentSessionSnapshot;
  Stream<SessionSnapshot> get sessionSnapshots;
  Future<void> resume();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> skipToNext();
  Future<void> skipToPrevious();
}

/// System media session adapter (Android MediaSession / notification /
/// quick settings / lock screen / media buttons).
///
/// It owns NO playback state: it mirrors [MediaEngine] and delegates every
/// action back to it, so the app and the OS can never disagree.
class VibeGrabAudioHandler extends BaseAudioHandler with SeekHandler {
  final MediaEngineDelegate _engine;
  StreamSubscription<SessionSnapshot>? _snapSub;

  VibeGrabAudioHandler(this._engine) {
    _init();
  }

  void _init() {
    // MediaEngine emits a snapshot on every position/duration/state change
    // for audio AND video — one stream feeds progress, duration and speed.
    _snapSub = _engine.sessionSnapshots.listen((s) {
      playbackState.add(playbackState.value.copyWith(
        updatePosition: s.position,
        bufferedPosition: s.bufferedPosition,
        speed: s.speed,
      ));
      final item = mediaItem.value;
      if (item != null &&
          s.duration > Duration.zero &&
          item.duration != s.duration) {
        mediaItem.add(item.copyWith(duration: s.duration));
      }
    });
  }

  @override
  Future<void> updateMediaItem(MediaItem newMediaItem) {
    mediaItem.add(newMediaItem);
    return Future.value();
  }

  void updatePlaybackState({
    required bool playing,
    required AudioProcessingState processingState,
  }) {
    final s = _engine.currentSessionSnapshot;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processingState,
      playing: playing,
      updatePosition: s.position,
      bufferedPosition: s.bufferedPosition,
      speed: s.speed,
    ));
  }

  @override
  Future<void> play() => _engine.resume();

  @override
  Future<void> pause() => _engine.pause();

  @override
  Future<void> stop() async {
    await _engine.stop();
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  }

  @override
  Future<void> seek(Duration position) => _engine.seek(position);

  @override
  Future<void> skipToNext() => _engine.skipToNext();

  @override
  Future<void> skipToPrevious() => _engine.skipToPrevious();

  @override
  Future<void> setSpeed(double speed) => _engine.audioPlayer.setSpeed(speed);

  @override
  Future<void> onTaskRemoved() async {
    await stop();
  }

  void dispose() {
    _snapSub?.cancel();
  }
}
