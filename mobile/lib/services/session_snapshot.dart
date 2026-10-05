/// Unified playback metrics emitted by [MediaEngine] on every meaningful
/// change. This is the single source of truth the OS media session reads,
/// so it stays correct for both the audio player and the video player.
class SessionSnapshot {
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final double speed;

  const SessionSnapshot({
    required this.position,
    required this.duration,
    required this.bufferedPosition,
    required this.speed,
  });
}
