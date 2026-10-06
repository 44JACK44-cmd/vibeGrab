import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'session_snapshot.dart';

abstract class MediaEngineDelegate {
  AudioPlayer get audioPlayer;
  SessionSnapshot get currentSessionSnapshot;
  Stream<SessionSnapshot> get sessionSnapshots;
  bool get isPlaying;
  bool get isCurrentFavorite;
  Future<void> resume();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> skipToNext();
  Future<void> skipToPrevious();
  void toggleRepeat();
  Future<void> toggleFavoriteCurrent();
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
    final prev = mediaItem.value;
    if (prev?.id != newMediaItem.id || prev?.duration != newMediaItem.duration) {
      debugPrint('[MEDIA_SESSION] MediaItem updated: "${newMediaItem.title}" '
          'by "${newMediaItem.artist}" dur=${newMediaItem.duration} '
          'art=${newMediaItem.artUri ?? "none"}');
    }
    mediaItem.add(newMediaItem);
    return Future.value();
  }

  void updatePlaybackState({
    required bool playing,
    required AudioProcessingState processingState,
  }) {
    final s = _engine.currentSessionSnapshot;
    playbackState.add(playbackState.value.copyWith(
      // System media card design (lock screen / quick settings /
      // notification): repeat, previous, play/pause, next, favorite.
      //
      // EVERY button is a custom action on purpose: the local audio_service
      // fork turns them into real broadcast PendingIntents that land in
      // [onCustomAction], so each button works deterministically instead of
      // depending on the platform media-button keycode mapping.
      controls: [
        MediaControl.custom(
          androidIcon: 'drawable/ic_vibegrab_repeat',
          label: 'Repetir',
          name: 'repeat',
        ),
        MediaControl.custom(
          androidIcon: 'drawable/audio_service_skip_previous',
          label: 'Anterior',
          name: 'prev',
        ),
        MediaControl.custom(
          androidIcon: playing
              ? 'drawable/audio_service_pause'
              : 'drawable/audio_service_play_arrow',
          label: playing ? 'Pausa' : 'Reproducir',
          name: 'playpause',
        ),
        MediaControl.custom(
          androidIcon: 'drawable/audio_service_skip_next',
          label: 'Siguiente',
          name: 'next',
        ),
        MediaControl.custom(
          androidIcon: _engine.isCurrentFavorite
              ? 'drawable/ic_vibegrab_favorite_filled'
              : 'drawable/ic_vibegrab_favorite',
          label: 'Me gusta',
          name: 'favorite',
        ),
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [1, 2, 3],
      processingState: processingState,
      playing: playing,
      updatePosition: s.position,
      bufferedPosition: s.bufferedPosition,
      speed: s.speed,
    ));
  }

  /// Re-pushes the playback state so the notification redraws its buttons
  /// (used when the heart / repeat state changes).
  void refreshControls() {
    updatePlaybackState(
      playing: playbackState.value.playing,
      processingState: playbackState.value.processingState,
    );
  }

  /// The platform delivers notification custom-action taps here (the
  /// deprecated name is what audio_service actually calls on this path).
  @override
  Future<dynamic> onCustomAction(String name, dynamic arguments) async {
    debugPrint('[MEDIA_SESSION] Custom action from system: $name');
    switch (name) {
      case 'repeat':
        _engine.toggleRepeat();
        break;
      case 'prev':
        await _engine.skipToPrevious();
        break;
      case 'next':
        await _engine.skipToNext();
        break;
      case 'playpause':
        if (_engine.isPlaying) {
          await _engine.pause();
        } else {
          await _engine.resume();
        }
        break;
      case 'favorite':
        await _engine.toggleFavoriteCurrent();
        break;
    }
    return null;
  }

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) =>
      onCustomAction(name, extras);

  @override
  Future<void> play() {
    debugPrint('[MEDIA_SESSION] Play (from system/app)');
    return _engine.resume();
  }

  @override
  Future<void> pause() {
    debugPrint('[MEDIA_SESSION] Pause (from system/app)');
    return _engine.pause();
  }

  @override
  Future<void> stop() async {
    debugPrint('[MEDIA_SESSION] Service stopped');
    await _engine.stop();
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  }

  @override
  Future<void> seek(Duration position) {
    debugPrint('[MEDIA_SESSION] Seek -> $position');
    return _engine.seek(position);
  }

  @override
  Future<void> skipToNext() {
    debugPrint('[MEDIA_SESSION] Next');
    return _engine.skipToNext();
  }

  @override
  Future<void> skipToPrevious() {
    debugPrint('[MEDIA_SESSION] Previous');
    return _engine.skipToPrevious();
  }

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
