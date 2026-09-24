import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

abstract class MediaEngineDelegate {
  AudioPlayer get audioPlayer;
  Future<void> resume();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> skipToNext();
  Future<void> skipToPrevious();
}

class VibeGrabAudioHandler extends BaseAudioHandler with SeekHandler {
  final MediaEngineDelegate _engine;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;

  VibeGrabAudioHandler(this._engine) {
    _init();
  }

  void _init() {
    _posSub = _engine.audioPlayer.positionStream.listen((pos) {
      playbackState.add(playbackState.value.copyWith(
        updatePosition: pos,
      ));
    });

    _durSub = _engine.audioPlayer.durationStream.listen((dur) {
      if (dur != null && mediaItem.value != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: dur));
      }
    });

    _stateSub = _engine.audioPlayer.playerStateStream.listen((ps) {
      final playing = ps.playing;
      final processingState = ps.processingState;

      AudioProcessingState audioProcessingState;
      switch (processingState) {
        case ProcessingState.idle:
          audioProcessingState = AudioProcessingState.idle;
          break;
        case ProcessingState.loading:
          audioProcessingState = AudioProcessingState.loading;
          break;
        case ProcessingState.buffering:
          audioProcessingState = AudioProcessingState.buffering;
          break;
        case ProcessingState.ready:
          audioProcessingState = AudioProcessingState.ready;
          break;
        case ProcessingState.completed:
          audioProcessingState = AudioProcessingState.completed;
          break;
      }

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
        processingState: audioProcessingState,
        playing: playing,
        updatePosition: _engine.audioPlayer.position,
        bufferedPosition: _engine.audioPlayer.bufferedPosition,
        speed: _engine.audioPlayer.speed,
      ));
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
      updatePosition: _engine.audioPlayer.position,
      bufferedPosition: _engine.audioPlayer.bufferedPosition,
      speed: _engine.audioPlayer.speed,
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
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
  }
}
