"""Upload pipeline: the device sends the bytes, the server only encodes.

The production host may not be able to reach a provider's media servers
(datacenter IPs get blocked), while the phone can. These tests cover the two
operations that replace the broken server-side download:

* ``encode_mp3``   – an uploaded audio track becomes a real MP3 with tags and
  cover (the same ffmpeg encoder used by the URL route).
* ``merge_tracks`` – an uploaded video-only track plus an audio-only track
  become one real container with both streams.

The ffmpeg tests skip themselves when no binary is available; the argument
tests always run.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

from app.core.config import settings
from app.services import audio_service as audio


def _ffmpeg() -> str | None:
    return shutil.which(settings.FFMPEG_PATH) or (
        settings.FFMPEG_PATH if Path(settings.FFMPEG_PATH).exists() else None
    )


requires_ffmpeg = pytest.mark.skipif(_ffmpeg() is None, reason="no ffmpeg available")


def _make_audio(path: Path, seconds: int = 2) -> None:
    subprocess.run(
        [
            _ffmpeg(), "-y", "-f", "lavfi",
            "-i", f"sine=frequency=440:duration={seconds}",
            "-c:a", "aac", str(path),
        ],
        capture_output=True,
        check=True,
    )


def _make_video(path: Path, seconds: int = 2) -> None:
    subprocess.run(
        [
            _ffmpeg(), "-y", "-f", "lavfi",
            "-i", f"testsrc=size=320x180:rate=24:duration={seconds}",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", str(path),
        ],
        capture_output=True,
        check=True,
    )


# --- encode_mp3 ------------------------------------------------------------


def test_encode_mp3_requires_a_non_empty_source(tmp_path):
    missing = tmp_path / "nope.m4a"
    with pytest.raises(audio.AudioConversionError):
        audio.encode_mp3(tmp_path, missing)

    empty = tmp_path / "empty.m4a"
    empty.write_bytes(b"")
    with pytest.raises(audio.AudioConversionError):
        audio.encode_mp3(tmp_path, empty)


@requires_ffmpeg
def test_encode_mp3_from_an_uploaded_track(tmp_path, monkeypatch):
    source = tmp_path / "upload.m4a"
    cover = tmp_path / "cover.jpg"
    _make_audio(source)
    subprocess.run(
        [
            _ffmpeg(), "-y", "-f", "lavfi",
            "-i", "color=c=green:s=64x64:d=1",
            "-frames:v", "1", str(cover),
        ],
        capture_output=True,
        check=True,
    )

    # The cover is normally downloaded from a public URL; point the downloader
    # at the fixture so the APIC wiring is exercised without the network.
    monkeypatch.setattr(audio, "_public_host", lambda url: True)
    monkeypatch.setattr(
        audio, "_download", lambda url, dest, limit, *, allowlist: shutil.copy(cover, dest)
    )

    out = audio.encode_mp3(
        tmp_path, source, title="Subida", artist="VibeGrab",
        cover_url="https://i.ytimg.com/vi/x/hq.jpg",
    )

    assert out.exists() and out.stat().st_size > 0
    assert out.suffix == ".mp3"

    from mutagen.id3 import ID3
    from mutagen.mp3 import MP3

    assert MP3(str(out)).info.length > 1
    tags = ID3(str(out))
    assert str(tags.get("TIT2")) == "Subida"
    assert str(tags.get("TPE1")) == "VibeGrab"
    assert tags.getall("APIC"), "the cover must be embedded"


@requires_ffmpeg
def test_encode_mp3_skips_an_unreachable_cover(tmp_path, monkeypatch):
    """A broken cover must not lose the audio."""
    source = tmp_path / "upload.m4a"
    _make_audio(source)

    def fail(*_args, **_kwargs):
        raise audio.AudioConversionError("cover unavailable")

    monkeypatch.setattr(audio, "_public_host", lambda url: True)
    monkeypatch.setattr(audio, "_download", fail)
    monkeypatch.setattr(audio, "_MAX_COVER_BYTES", 10)

    out = audio.encode_mp3(
        tmp_path, source, title="Sin portada", cover_url="https://i.ytimg.com/x.jpg"
    )
    assert out.exists() and out.stat().st_size > 0


# --- merge_tracks ----------------------------------------------------------


def test_merge_rejects_missing_tracks(tmp_path):
    video = tmp_path / "v.mp4"
    audio_track = tmp_path / "a.m4a"
    video.write_bytes(b"video")
    with pytest.raises(audio.AudioConversionError):
        audio.merge_tracks(tmp_path, video, audio_track)


@requires_ffmpeg
def test_merge_produces_a_real_container_with_both_streams(tmp_path):
    video = tmp_path / "video.mp4"
    track = tmp_path / "audio.m4a"
    _make_video(video)
    _make_audio(track)

    out, ext = audio.merge_tracks(tmp_path, video, track)

    assert out.exists() and out.stat().st_size > 0
    assert ext in ("mp4", "mkv")
    assert out.suffix == f".{ext}"

    probe = subprocess.run(
        [
            _ffmpeg(), "-i", str(out), "-hide_banner",
        ],
        capture_output=True,
        text=True,
    )
    # ffmpeg exits 1 without an output file but still prints the streams.
    info = probe.stderr
    assert "Video:" in info
    assert "Audio:" in info


@requires_ffmpeg
def test_merge_is_not_a_muted_video(tmp_path):
    """The exact failure this replaces: a video-only file saved as complete."""
    video = tmp_path / "video.mp4"
    track = tmp_path / "audio.m4a"
    _make_video(video)
    _make_audio(track)

    out, _ = audio.merge_tracks(tmp_path, video, track)

    probe = subprocess.run(
        [_ffmpeg(), "-i", str(out), "-hide_banner"],
        capture_output=True,
        text=True,
    )
    assert "Audio:" in probe.stderr
